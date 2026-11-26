// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

/// A password envelope of another vault can replace this library's vault only while iCloud sync is switched off (v1): the
/// settings UI asks the person to turn sync off, convert, and turn it on again.
public enum CloudVaultConversionError: Error, Equatable, Sendable {
    case syncMustBeOff
}

/// What one `applyPending` run did, by entity.
public struct CloudApplyReport: Sendable, Equatable {
    public var applied: [CloudEntityRef] = []
    /// A version that was already covered by the base pair (an echo, or older): dropped, nothing written.
    public var dropped: [CloudEntityRef] = []
    public var waitingForDependency: [CloudEntityRef] = []
    public var waitingForUnlock: [CloudEntityRef] = []
    public var waitingForUpload: [CloudEntityRef] = []
    /// Unreadable when opened (authentication failure, unknown payload kind or shape): moved to quarantine, entity fenced.
    public var quarantined: [CloudEntityRef] = []
    /// Skipped because a quarantine row fences the entity.
    public var fenced: [CloudEntityRef] = []
    /// The base moved while the merge was computed; the next pass retries.
    public var retried: [CloudEntityRef] = []
    public var passwordChanged = false
    public init() {}
}

/// Applies the fetched versions waiting in `ck_remote`: in dependency order (key bundle entity, notes, attachments, then
/// tags, settings and external references), to a fixpoint; each in one transaction that also moves the base pair, drops the
/// snapshot of ours that was in flight and lifts the pause. Fetching never touches the library; this does, and only this.
///
/// Merge contract (Task 5): the ancestor of a merge is `CloudOutcomeResolver.mergeBase` while a snapshot of ours is in flight and
/// the base pair's ancestor otherwise (nil on first contact); a conflict copy is identified by `conflictIdentity`; the snapshot
/// is dropped inside the apply transaction, which also clears a pause (a record that is back in the cloud is adopted by merge,
/// not ignored).
public struct CloudReconciler: Sendable {
    let database: AppDatabase
    let paths: AppPaths
    let store: CloudSyncStore
    let accountID: String
    let applier: CloudApplier
    let reader: CloudRemoteReader
    let pinner: CloudAssetPinner
    let crash: CrashPoint
    let generation: @Sendable () throws -> Int64
    let noteAccess: @Sendable () -> LockedNoteAccess?
    let notePassword: @Sendable () -> String?
    let firstContactVersions: @Sendable (SyncEntityType, String) -> [Data]
    let locallyDeletedStarters: Set<String>

    /// - Parameters:
    ///   - firstContactVersions: the sealed contents an entity may have started from when this device holds no base pair for it,
    /// oldest first (the shipped Getting Started texts); empty means an empty base. Only consulted on first contact.
    ///   - blobs: how an attachment ciphertext becomes a verified local file; the default reads the local cache (`sync_blob_state`).
    ///   - generation: the account generation of this run; the default reads the current one (a coordinator passes the captured one).
    public init(database: AppDatabase, paths: AppPaths, store: CloudSyncStore, accountID: String, vaultKey: SymmetricKey,
                pinner: CloudAssetPinner, blobs: (any SyncBlobTransport)? = nil, coordinator: (any SyncCommitCoordinator)? = nil,
                crash: CrashPoint = .never, generation: (@Sendable () throws -> Int64)? = nil,
                noteAccess: @escaping @Sendable () -> LockedNoteAccess? = { nil }, notePassword: @escaping @Sendable () -> String? = { nil },
                firstContactVersions: @escaping @Sendable (SyncEntityType, String) -> [Data] = { _, _ in [] },
                locallyDeletedStarters: Set<String> = []) {
        self.firstContactVersions = firstContactVersions; self.locallyDeletedStarters = locallyDeletedStarters
        self.database = database; self.paths = paths; self.store = store; self.accountID = accountID; self.pinner = pinner; self.crash = crash
        self.generation = generation ?? { try store.generation() }
        self.noteAccess = noteAccess; self.notePassword = notePassword
        reader = CloudRemoteReader(sealer: CloudPayloadSealer(accountID: accountID, vaultKey: vaultKey))
        applier = CloudApplier(database: database, paths: paths, accountID: accountID, vaultKey: vaultKey,
                               blobs: blobs ?? CloudLocalBlobTransport(database: database, paths: paths), coordinator: coordinator)
    }

    private static func rank(_ type: String) -> Int {
        switch type {
        case "keyBundle": return 0
        case "note": return 1
        case "attachment": return 2
        case "externalRef": return 4
        default: return 3
        }
    }

    /// Applies until a pass makes no progress (an attachment that had to wait for its note, an external reference that waited
    /// for its note, a note that waited for the key bundle).
    @discardableResult
    public func applyPending(maxPasses: Int = 8) async throws -> CloudApplyReport {
        var report = CloudApplyReport()
        for _ in 0..<maxPasses {
            var progressed = false
            var pass = CloudApplyReport()
            let pending = try store.allRemote().sorted { (Self.rank($0.entity.entityType), $0.recordName) < (Self.rank($1.entity.entityType), $1.recordName) }
            for listed in pending {
                // An earlier version of this pass may have consumed or replaced it.
                guard let remote = try store.remote(recordName: listed.recordName), remote.ver == listed.ver, remote.sid == listed.sid else { continue }
                switch try await applyOne(remote) {
                case .applied(let changed, let passwordChanged):
                    pass.applied.append(remote.entity); progressed = progressed || changed || true
                    pass.passwordChanged = pass.passwordChanged || passwordChanged
                case .dropped: pass.dropped.append(remote.entity); progressed = true
                case .waiting(let kind):
                    switch kind {
                    case .dependency: pass.waitingForDependency.append(remote.entity)
                    case .unlock: pass.waitingForUnlock.append(remote.entity)
                    case .upload: pass.waitingForUpload.append(remote.entity)
                    }
                case .quarantined: pass.quarantined.append(remote.entity); progressed = true
                case .fenced: pass.fenced.append(remote.entity)
                case .retry: pass.retried.append(remote.entity)
                }
            }
            report.applied += pass.applied; report.dropped += pass.dropped; report.quarantined += pass.quarantined
            report.passwordChanged = report.passwordChanged || pass.passwordChanged
            // What is still waiting after the last pass is what the report says is waiting.
            report.waitingForDependency = pass.waitingForDependency; report.waitingForUnlock = pass.waitingForUnlock
            report.waitingForUpload = pass.waitingForUpload; report.fenced = pass.fenced; report.retried = pass.retried
            if !progressed { break }
        }
        return report
    }

    private enum Step {
        case applied(changed: Bool, passwordChanged: Bool), dropped, quarantined, fenced, retry
        enum Wait { case dependency, unlock, upload }
        case waiting(Wait)
    }

    // MARK: one fetched version

    private func applyOne(_ remote: CloudRemoteVersion) async throws -> Step {
        let entity = remote.entity
        let gen = try generation()
        guard let type = SyncEntityType(rawValue: entity.entityType) else {
            return try await quarantine(remote, reason: "payload:unknownEntityType")
        }
        // A quarantine fences the entity. A version that is provably newer than the quarantined record may release it, but only
        // once it was opened, validated and applied, in one transaction; a version that fails to open leaves the quarantined
        // record and its pinned copy exactly as they are.
        var releasing = false
        var inspectedQuarantine: Data?
        if try store.isFenced(entityType: entity.entityType, entityId: entity.entityId) {
            guard let row = try store.quarantineRow(recordName: remote.recordName), !row.ignoredByUser, Self.supersedes(remote, row) else { return .fenced }
            releasing = true
            inspectedQuarantine = row.rawFields
        }
        let pair = try store.pair(for: entity)
        // Already covered by the pair (an echo of our own save that was applied meanwhile, or an older version): nothing to merge.
        if let pair, pair.inc == remote.inc, pair.ver > remote.ver || (pair.ver == remote.ver && pair.systemFields == remote.systemFields) {
            pinner.remove(try store.deleteRemote(remote, accountGeneration: gen))
            return .dropped
        }
        let sealed = try loadSealed(remote)
        let value: SyncRemoteValue
        do { value = try reader.read(sealed: sealed, type: type, entityId: entity.entityId, blobRefs: remote.blobRefs) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if releasing { return .fenced }
            return try await quarantine(remote, reason: Self.reason(for: error), payloadSize: Int64(sealed.count))
        }

        let inflight = try store.inflight(for: entity)
        // The merge base. Inside one incarnation versions are totally ordered, so the remote is newer than the
        // ancestor we hold (or than the base of our snapshot in flight). Across incarnations nothing orders them: a recovery
        // creates a new history from whatever the recovering device held, which may be older than what we hold, so a list of
        // superseded incarnations proves nothing about content. The remote counts as a descendant only if it is provably one: it
        // descends from our own snapshot (our attempt id is its own or in its chain), or it is exactly the version we hold. In
        // every other case it is an independent snapshot: the merge base is empty (notes keep both, the local one at the id and
        // the remote one as the deterministic copy; metadata keeps the local value). Clean or dirty makes no difference.
        var baseSealed: Data?
        var independent = false
        if pair == nil || pair?.inc == remote.inc {
            baseSealed = inflight.flatMap { CloudOutcomeResolver.mergeBase(attempt: $0, remote: remote) } ?? (inflight == nil ? pair?.ancestor : nil)
        } else if let inflight, remote.sid == inflight.attemptId || remote.sids.contains(inflight.attemptId) {
            baseSealed = inflight.sealed
        } else {
            let held = inflight.map(\.baseAncestor) ?? pair?.ancestor
            if let held, let heldValue = try? reader.read(sealed: held, type: type, entityId: entity.entityId, blobRefs: nil), value.sameContent(as: heldValue) {
                baseSealed = held
            } else { independent = true }
        }
        // First contact (no base pair): the seed content the entity is known to have started from, if there is one.
        var shipped: [SyncNotePayload] = []
        if pair == nil, baseSealed == nil, !independent {
            let versions = firstContactVersions(type, entity.entityId)
            baseSealed = versions.first
            shipped = versions.compactMap { sealedVersion in
                if case .note(let note)? = try? reader.read(sealed: sealedVersion, type: type, entityId: entity.entityId, blobRefs: nil) { return note }
                return nil
            }
        }
        let base = try baseSealed.map { try reader.read(sealed: $0, type: type, entityId: entity.entityId, blobRefs: nil) }
        let identity = inflight.map { CloudOutcomeResolver.conflictIdentity(attempt: $0, remote: remote) } ?? (remote.sid, remote.ver)
        let version = RemoteVersion(entityType: type, entityId: entity.entityId, ver: remote.ver, sid: remote.sid, sealed: sealed,
                                    blobRefs: remote.blobRefs, lineage: remote.inc)
        let expected = pair.map { Self.token($0) }
        let store = self.store, reader = self.reader, crash = self.crash, pinner = self.pinner
        let leftovers = PathBox()
        let input = CloudApplyInput(
            version: version, value: value, base: base, hasBase: baseSealed != nil, mergeIdentity: identity, mergingInflight: inflight != nil,
            siblings: { siblingType, id in Self.sibling(siblingType, id, store: store, reader: reader, pinner: pinner) },
            precondition: { db in
                guard try CloudSyncStore.pair(db, entity).map({ Self.token($0) }) == expected else { throw CloudApplyRetry(reason: "pair-moved") }
            },
            siblingStillCurrent: { db, siblingType, id, sibling in
                let ref = CloudEntityRef(entityType: siblingType.rawValue, entityId: id)
                guard let pair = try CloudSyncStore.pair(db, ref) else { return true }
                return !(pair.inc == sibling.lineage && pair.ver > sibling.ver)
            },
            lockEnvelopeWaiting: try store.allRemote().contains { $0.entity.entityType == "keyBundle" && $0.waitingFor == .unlock },
            independent: independent,
            consumeSiblings: { db, siblings in
                for (id, sibling) in siblings {
                    let ref = CloudEntityRef(entityType: "attachment", entityId: id)
                    // Exactly the version that was downloaded and installed; anything else moved on while the note was prepared.
                    guard let row = try CloudSyncStore.remote(db, ref.recordName), row.inc == sibling.lineage, row.ver == sibling.ver, row.sid == sibling.sid
                    else { throw CloudApplyRetry(reason: "attachment-moved") }
                    try CloudSyncStore.applyVersion(db, remote: row, ancestor: sibling.sealed)
                    for attempt in try CloudSyncStore.fetchInflight(db, sql: "WHERE entityType=? AND entityId=?", [ref.entityType, ref.entityId]) {
                        try CloudSyncStore.dropInflight(db, attemptId: attempt.attemptId)
                    }
                    try db.execute(sql: "DELETE FROM ck_missing WHERE entityType=? AND entityId=?", arguments: [ref.entityType, ref.entityId])
                    if let path = row.sealedPath { leftovers.add([path]) }
                }
            },
            requireUnpublishedProtectedLibrary: { db in try Self.requireUnpublishedProtectedLibrary(in: db) },
            isUnpublishedNote: { db, id in try Self.isUnpublished(note: id, in: db) },
            noteAccess: noteAccess(), remoteNotePassword: notePassword(), firstContact: pair == nil, shipped: shipped,
            locallyDeleted: pair == nil && type == .note && locallyDeletedStarters.contains(entity.entityId),
            parentHistory: { id in
                let ref = CloudEntityRef(entityType: "note", entityId: id)
                guard let pair = try? store.pair(for: ref) else { return nil }
                let value = try? reader.read(sealed: pair.ancestor, type: .note, entityId: id, blobRefs: nil)
                return CloudSibling(value: value ?? .deleted, lineage: pair.inc, ver: pair.ver, sid: pair.sids.first ?? "", sealed: pair.ancestor, pending: false, privacyUnknown: value == nil)
            },
            parentHistoryStillCurrent: { db, id, history in
                guard let pair = try CloudSyncStore.pair(db, CloudEntityRef(entityType: "note", entityId: id)) else { return history == nil }
                guard let history else { return false }
                return pair.inc == history.lineage && pair.ver == history.ver && pair.ancestor == history.sealed
            })
        let fenceLifts = releasing
        let expectedQuarantine = inspectedQuarantine
        let commit: CloudApplyCommit = { write in
            let released = try store.recordApplied(accountGeneration: gen, remote: remote, ancestor: sealed, releasingQuarantine: fenceLifts, expectedQuarantine: expectedQuarantine, libraryWrite: { db in
                try write(db)
                try crash.hit("applier.afterLibraryWrite")
                // The merge covers the content of any snapshot of ours (it is in the library and in the dirty generation).
                for attempt in try CloudSyncStore.fetchInflight(db, sql: "WHERE entityType=? AND entityId=?", [entity.entityType, entity.entityId]) {
                    try CloudSyncStore.dropInflight(db, attemptId: attempt.attemptId)
                }
                // The record is in the cloud again: the pause lifts.
                try db.execute(sql: "DELETE FROM ck_missing WHERE entityType=? AND entityId=?", arguments: [entity.entityType, entity.entityId])
            })
            leftovers.add(released)
        }

        let outcome: CloudApplyOutcome
        do { outcome = try await applier.apply(input, commit: commit) }
        catch let retry as CloudApplyRetry { _ = retry; return .retry }
        catch CloudSyncStoreError.quarantineChanged { return .retry }
        catch CloudSyncStoreError.wouldRegressPair {
            pinner.remove(try store.deleteRemote(remote, accountGeneration: gen)); return .dropped
        } catch CloudSyncStoreError.entityFenced { return .fenced }
        catch SyncApplyError.identityCollision {
            if releasing { return .fenced }
            return try await quarantine(remote, reason: "payload:identityCollision", payloadSize: Int64(sealed.count))
        } catch is SyncProtocolError {
            if releasing { return .fenced }
            return try await quarantine(remote, reason: "payload:invalid", payloadSize: Int64(sealed.count))
        }
        switch outcome {
        case .applied, .passwordChanged:
            if let path = remote.sealedPath { leftovers.add([path]) }
            pinner.remove(try store.unreferencedPaths(leftovers.all))
            try crash.hit("applier.afterNote")
            return .applied(changed: true, passwordChanged: outcome == .passwordChanged)
        case .waitingForDependencies: try store.setWaiting(remote, .dependency, accountGeneration: gen); return .waiting(.dependency)
        case .waitingForUnlock: try store.setWaiting(remote, .unlock, accountGeneration: gen); return .waiting(.unlock)
        case .waitingForUpload: return .waiting(.upload)
        }
    }

    /// Provably newer than the quarantined record: the same incarnation with a higher `ver`, or an incarnation that lists the
    /// quarantined one as superseded.
    static func supersedes(_ remote: CloudRemoteVersion, _ row: CloudQuarantineRow) -> Bool {
        guard let record = try? JSONDecoder().decode(CloudRecord.self, from: row.rawFields),
              case .string(let inc)? = record.fields["inc"], case .int(let ver)? = record.fields["ver"] else { return false }
        // The quarantined version itself, now understood (a newer build), also qualifies: it releases the row once applied.
        if inc == remote.inc, ver == remote.ver, case .string(let sid)? = record.fields["sid"], sid == remote.sid { return true }
        return inc == remote.inc ? remote.ver > ver : remote.incs.contains(inc)
    }

    // MARK: reading

    func loadSealed(_ remote: CloudRemoteVersion) throws -> Data {
        if let sealed = remote.sealed { return sealed }
        guard let path = remote.sealedPath, let sha = remote.sealedSha256 else { throw CloudIntakeError.pinMismatch(remote.recordName) }
        let data = try Data(contentsOf: pinner.url(for: path))
        guard CloudSyncStore.sha256Hex(data) == sha else { throw CloudIntakeError.pinMismatch(path) }
        return data
    }

    /// The version of another entity a note may depend on: its fetched version waiting in `ck_remote`, else the version already
    /// applied (the base pair's ancestor).
    static func sibling(_ type: SyncEntityType, _ id: String, store: CloudSyncStore, reader: CloudRemoteReader, pinner: CloudAssetPinner) -> CloudSibling? {
        let ref = CloudEntityRef(entityType: type.rawValue, entityId: id)
        if let pending = try? store.remote(recordName: ref.recordName), !((try? store.isFenced(entityType: ref.entityType, entityId: ref.entityId)) ?? true) {
            let sealed: Data?
            if let inline = pending.sealed { sealed = inline }
            else if let path = pending.sealedPath, let data = try? Data(contentsOf: pinner.url(for: path)) { sealed = data }
            else { sealed = nil }
            if let sealed, let value = try? reader.read(sealed: sealed, type: type, entityId: id, blobRefs: pending.blobRefs) {
                var independent = false
            if let pair = try? store.pair(for: ref), pair.inc != pending.inc {
                let held = try? reader.read(sealed: pair.ancestor, type: type, entityId: id, blobRefs: nil)
                independent = !(held.map { value.sameContent(as: $0) } ?? false)
            }
            return CloudSibling(value: value, lineage: pending.inc, ver: pending.ver, sid: pending.sid, sealed: sealed, independent: independent, pending: true)
            }
            return nil
        }
        if let pair = try? store.pair(for: ref), let value = try? reader.read(sealed: pair.ancestor, type: type, entityId: id, blobRefs: nil) {
            return CloudSibling(value: value, lineage: pair.inc, ver: pair.ver, sid: pair.sids.first ?? "", sealed: pair.ancestor, pending: false)
        }
        return nil
    }

    /// A protected note that was ever published (a base pair, a snapshot in flight, a paused entity, or a fetched version waiting)
    /// lives under a vault key other devices hold. Rewriting it under another key would break its published history, so a
    /// conversion to another vault is refused (`SyncNotePasswordError.differentVaults`). The guard of the Cloudflare original reads
    /// `sync_outbox` and `sync_shadow`, which are always empty in this library, so it passes vacuously; this one asks the tables
    /// that hold the truth. It runs inside the transaction that does the conversion, so a publish cannot slip in between the check
    /// and the rewrite: a snapshot already prepared counts.
    static func requireUnpublishedProtectedLibrary(in db: Database) throws {
        // The reused conversion refuses every library with sync switched on; say so with a typed error the settings UI can map to
        // "turn iCloud sync off first" instead of the generic "different vaults".
        if try Bool.fetchOne(db, sql: "SELECT enabled FROM sync_control WHERE id=1") == true { throw CloudVaultConversionError.syncMustBeOff }
        let published = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM note n WHERE n.isLocked=1 AND (
                   EXISTS(SELECT 1 FROM ck_record r WHERE r.entityType='note' AND r.entityId=n.id)
                OR EXISTS(SELECT 1 FROM ck_inflight f WHERE f.entityType='note' AND f.entityId=n.id)
                OR EXISTS(SELECT 1 FROM ck_missing m WHERE m.entityType='note' AND m.entityId=n.id)
                OR EXISTS(SELECT 1 FROM ck_remote x WHERE x.entityType='note' AND x.entityId=n.id)))
            """) ?? false
        guard !published else { throw SyncNotePasswordError.differentVaults }
    }

    static func isUnpublished(note id: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM ck_record WHERE entityType='note' AND entityId=?)
              AND NOT EXISTS(SELECT 1 FROM ck_inflight WHERE entityType='note' AND entityId=?)
            """, arguments: [id, id]) ?? false
    }

    static func token(_ pair: CloudBasePair) -> PairToken {
        PairToken(systemFields: pair.systemFields, ver: pair.ver, inc: pair.inc, ancestor: pair.ancestor)
    }
    struct PairToken: Equatable, Sendable { let systemFields: Data; let ver: Int64; let inc: String; let ancestor: Data }

    // MARK: unreadable when opened

    static func reason(for error: Error) -> String {
        if case CryptoError.tampered = error { return "payload:authentication" }
        if let protocolError = error as? SyncProtocolError, case .unsupportedVersion = protocolError { return "payload:unsupported" }
        return "payload:invalid"
    }

    private func quarantine(_ remote: CloudRemoteVersion, reason: String, payloadSize: Int64 = 0) async throws -> Step {
        let obsolete = try store.quarantineRemote(remote, reason: reason, payloadSize: payloadSize, accountGeneration: try generation())
        pinner.remove(obsolete)
        return .quarantined
    }
}

/// Paths of pinned files to delete once the transaction that released them has committed.
final class PathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ more: [String]) { lock.withLock { paths += more } }
    var all: [String] { lock.withLock { paths } }
}

/// Serves attachment ciphertext from the local cache (`sync_blob_state`), verified against its hash and size. It never reaches the
/// network; Task 7's `CloudKitBlobTransfer` puts downloaded parts there.
struct CloudLocalBlobTransport: SyncBlobTransport {
    let database: AppDatabase
    let paths: AppPaths
    func ensureUploaded(_ hashes: [String]) async throws {}
    func download(hash: String) async throws -> URL {
        let found = try await database.pool.read { db -> (String, Int64)? in
            guard let row = try Row.fetchOne(db, sql: "SELECT localPath, byteSize FROM sync_blob_state WHERE hash=?", arguments: [hash]),
                  let path: String = row["localPath"] else { return nil }
            return (path, row["byteSize"])
        }
        guard let (path, size) = found else { throw SyncProtocolError.invalidPayload }
        return try SyncBlobLocation.verified(path, paths: paths, hash: hash, size: size).url
    }
}
