// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// The receiving side's writer. It takes plain values, merges them with the three-way rules the library already
// has (`SyncNoteMerge`, `SyncLockedNoteMerge`) and writes through the reused library writers (`SyncMaterializer.writeNote`,
// `writeMetadata`, the attachment staging). It imports no transport type and names no state table: the transaction, the base pair
// and the fetched-version bookkeeping are the caller's (`CloudReconciler`), handed in as `commit`.
//
// What was copied (E0 record, class c) and what replaced the Cloudflare engine's own bookkeeping:
//   shadow == ancestor race check      -> `precondition` (the caller checks that the base pair did not move)
//   sync_outbox "waitingForUpload"     -> nothing; a snapshot in flight is dropped by the caller in the same transaction
//   sync_inbox "waitingForUnlock"      -> the outcome `.waitingForUnlock`; the caller records it on the fetched version
//   `finish` (shadow, inbox, state)    -> `markEntity` (the id-map upsert) + the caller's `recordApplied`
//   `rejectedMutationID`               -> `mergeIdentity` + `mergingInflight`

/// A cloud version as the applier sees it: no change tag, no record, no table.
struct RemoteVersion: Sendable, Equatable {
    var entityType: SyncEntityType
    var entityId: String
    var ver: Int64
    var sid: String
    var sealed: Data
    var blobRefs: [String]
    /// Opaque: the history this version belongs to (the caller compares it, the applier never does).
    var lineage: String
}

/// Another entity's version the applier may need: the attachment descriptors of a note.
struct CloudSibling: Sendable {
    var value: SyncRemoteValue
    var lineage: String
    var ver: Int64
    /// The exact attempt that produced this version and its sealed bytes: what a note's commit consumes must be this version.
    var sid: String
    var sealed: Data
    /// A pending version of another incarnation whose content is not what this device holds: nothing says which is newer.
    var independent: Bool = false
    /// `true`: a fetched version still waiting to be applied (this commit consumes it); `false`: the version already applied.
    var pending: Bool
    /// Applied bytes could not be opened: useful only as a race token, never deletion proof.
    var privacyUnknown: Bool = false
}

struct CloudApplyInput: Sendable {
    var version: RemoteVersion
    var value: SyncRemoteValue
    var base: SyncRemoteValue?
    /// An ancestor exists (a base pair, or the base of a snapshot in flight). `false` is first contact (empty base).
    var hasBase: Bool
    /// `(mutation id, revision)` of a conflict copy: the fetched version's own `(sid, ver)`, or `(attempt id, ver)` while a
    /// snapshot of ours is in flight (`CloudOutcomeResolver.conflictIdentity`).
    var mergeIdentity: (mutationID: String, revision: Int64)
    /// A snapshot of ours for this entity is in flight and this commit drops it (the old "explicit CAS rejection").
    var mergingInflight: Bool
    var siblings: @Sendable (SyncEntityType, String) -> CloudSibling?
    /// Runs first inside the transaction: throws if the base this merge was computed against has moved.
    var precondition: @Sendable (Database) throws -> Void
    /// Checks that a pending sibling consumed by a note is still the newest one (the version check for downloads).
    var siblingStillCurrent: @Sendable (Database, SyncEntityType, String, CloudSibling) throws -> Bool
    /// The key-bundle (password envelope) version is waiting for the password: protected notes wait with it.
    var lockEnvelopeWaiting: Bool
    /// The remote version belongs to an incarnation that did not grow from what this device holds (an independent snapshot).
    /// Notes then merge against an empty base; settings, tag preferences and external references keep the local value.
    var independent: Bool
    /// Runs inside the note's transaction, after its writes: advances the base of every pending attachment version that was
    /// consumed, by the exact version that was downloaded; throws `CloudApplyRetry` if that version is no longer the pending one.
    var consumeSiblings: @Sendable (Database, [(id: String, sibling: CloudSibling)]) throws -> Void
    /// Throws `SyncNotePasswordError.differentVaults` when a protected note of this library was ever published (or is being
    /// published): rewriting it under another vault key would break its history. Runs inside the transaction that converts.
    var requireUnpublishedProtectedLibrary: @Sendable (Database) throws -> Void
    /// `true` when the note was never published and is not being published (an unpublished import may be collapsed).
    var isUnpublishedNote: @Sendable (Database, String) throws -> Bool
    var noteAccess: LockedNoteAccess?
    var remoteNotePassword: String?
    /// This device holds no base pair for the entity: whatever the library has is a local version the cloud never saw, even when
    /// `base` is a first-shipped seed. Such a note is always reconciled with the local one, never overwritten.
    var firstContact: Bool = false
    /// The shipped versions of a starter note, oldest first, when this is first contact with one. Empty otherwise.
    var shipped: [SyncNotePayload] = []
    /// The note is a starter note this device deleted before it ever met the cloud (no tombstone exists).
    var locallyDeleted: Bool = false
    /// Authenticated *applied* parent history, never a pending remote note. The caller
    /// rechecks its exact base pair in the same transaction as attachment recovery.
    var parentHistory: @Sendable (String) -> CloudSibling? = { _ in nil }
    var parentHistoryStillCurrent: @Sendable (Database, String, CloudSibling?) throws -> Bool = { _, _, _ in false }
}

enum CloudApplyOutcome: Equatable, Sendable {
    /// Applied; `consumed` are the pending attachment versions folded into the note's transaction (the caller advances their pairs).
    case applied(consumed: [String])
    case waitingForDependencies, waitingForUnlock, waitingForUpload
    case passwordChanged
}

/// Runs the write inside the transaction that also moves the base pair (and drops the snapshot in flight). Throwing from the
/// write rolls everything back.
typealias CloudApplyWrite = @Sendable (Database) throws -> Void
typealias CloudApplyCommit = @Sendable (@escaping CloudApplyWrite) throws -> Void

/// Thrown from a write to stop it: nothing is written, the pair does not move, the version stays for a later pass.
struct CloudApplyWait: Error { let outcome: CloudApplyOutcome }
/// The base or a sibling moved while the merge was computed; the caller retries on the next pass.
struct CloudApplyRetry: Error, Equatable { let reason: String }

final class CloudApplyScratch: @unchecked Sendable {
    var staged: [AttachmentFiles.Staged] = []
    var committed = false
}

struct CloudDownload: Sendable {
    let sibling: CloudSibling?
    let siblingId: String?
    let payload: SyncAttachmentPayload
    let cipher: URL
    var materialized: SyncMaterializer.DownloadedAttachment { .init(entity: nil, payload: payload, cipher: cipher) }
}

struct CloudApplier: Sendable {
    let database: AppDatabase
    let paths: AppPaths
    let accountID: String
    let vaultKey: SymmetricKey
    let materializer: SyncMaterializer
    let coordinator: (any SyncCommitCoordinator)?

    /// - Parameter blobs: how a referenced attachment ciphertext becomes a verified local file (Task 7's cache; `download(hash:)`
    ///   returns the local ciphertext and never reaches the network from here).
    init(database: AppDatabase, paths: AppPaths, accountID: String, vaultKey: SymmetricKey, blobs: any SyncBlobTransport,
         coordinator: (any SyncCommitCoordinator)? = nil) {
        self.database = database; self.paths = paths; self.accountID = accountID; self.vaultKey = vaultKey; self.coordinator = coordinator
        materializer = SyncMaterializer(database: database, paths: paths, accountID: accountID, vaultKey: vaultKey, blobs: blobs, coordinator: nil)
    }

    func apply(_ input: CloudApplyInput, commit: @escaping CloudApplyCommit) async throws -> CloudApplyOutcome {
        switch input.version.entityType {
        case .note: return try await applyNote(input, commit: commit)
        case .attachment: return try await applyAttachment(input, commit: commit)
        default:
            let authorized = try await authorizePasswordEnvelope(input.value, access: input.noteAccess, password: input.remoteNotePassword,
                                                                 requireUnpublished: input.requireUnpublishedProtectedLibrary)
            return try await coordinated(scope: .metadata(input.version.entityType)) { try applyMetadata(input, authorized: authorized, commit: commit) }
        }
    }

    /// The editor-session coordination of the host (`SyncCommitCoordinator`) wraps the synchronous local mutation only.
    func coordinated(scope: SyncCommitScope, _ change: @escaping @Sendable () throws -> CloudApplyOutcome) async throws -> CloudApplyOutcome {
        try Task.checkCancellation()
        guard let coordinator else { return try change() }
        let box = OutcomeBox()
        _ = try await coordinator.commit(scope: scope) { box.value = try change(); return .applied }
        return box.value ?? .waitingForDependencies
    }

    final class OutcomeBox: @unchecked Sendable { var value: CloudApplyOutcome? }

    // MARK: shared helpers

    /// The id-map upsert of `SyncMaterializer.finish`, minus the shadow and inbox parts. A local id that already maps to another
    /// entity id is an identity collision and rolls the whole apply back.
    static func markEntity(type: SyncEntityType, localID: String, entityID: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO sync_entity_state(entityType,localId,entityId,serverRevision) VALUES(?,?,?,0)
            ON CONFLICT(entityType,localId) DO UPDATE SET serverRevision=serverRevision WHERE entityId=excluded.entityId
            """, arguments: [type.rawValue, localID, entityID])
        guard db.changesCount == 1 else { throw SyncApplyError.identityCollision }
    }

    static func isDirty(_ type: String, _ id: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType=? AND localId=?)", arguments: [type, id]) == true
    }

    func requireAccount(_ db: Database) throws {
        guard try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1") == accountID else { throw SyncQueueError.accountMismatch }
    }

    /// The verified local ciphertext of an attachment, or `nil` while it is not (yet) available.
    func localCipher(_ attachment: SyncAttachmentPayload) async throws -> URL? {
        do { return try await materializer.preparedAttachmentCipher(attachment) }
        catch is CancellationError { throw CancellationError() }
        catch let injected as CrashInjected { throw injected }      // a crash is not "not available yet"
        catch { return nil }
    }

    /// Opens a note's attachment descriptors from the siblings of the caller and downloads their ciphertext (outside the writer).
    func downloads(for remote: SyncNotePayload?, noteID: String, input: CloudApplyInput) async throws -> (downloads: [CloudDownload], blocked: Bool) {
        var downloads: [CloudDownload] = []
        for id in remote?.attachmentIds ?? [] {
            let sibling = input.siblings(.attachment, id)
            var selected: (CloudSibling?, SyncAttachmentPayload)?
            if let sibling, case .attachment(let attachment) = sibling.value, attachment.noteId == noteID,
               attachment.isLocked == remote?.isLocked, remote?.attachmentNames?[id].map({ $0 == attachment.filename }) ?? true {
                selected = (sibling, attachment)
            }
            if selected == nil, let pinned = remote?.attachmentSnapshots?[id] { selected = (nil, pinned) }
            guard let (chosen, attachment) = selected else {
                // A known but incompatible representation is not a genuinely missing file.
                if sibling == nil, remote?.attachmentNames?[id] != nil { continue }
                if let sibling, case .deleted = sibling.value, remote?.attachmentNames?[id] != nil { continue }
                return ([], true)
            }
            // A blob that is not here yet (or not verified) is a missing dependency, not a damaged record: the note waits.
            guard let cipher = try await localCipher(attachment) else { return ([], true) }
            downloads.append(CloudDownload(sibling: chosen, siblingId: chosen.map { _ in id }, payload: attachment, cipher: cipher))
        }
        return (downloads, false)
    }
}
