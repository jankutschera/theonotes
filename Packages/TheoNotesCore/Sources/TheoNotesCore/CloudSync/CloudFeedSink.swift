// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

public enum CloudSinkError: Error, Equatable {
    /// A commit of this fetch threw, so the engine state that would follow it is withheld (the state is never ahead of the data).
    case stateWithheld
    /// A full refetch is never started after the zone was removed (CK-R15): the picture would be empty, not authoritative.
    case zoneRemoved
}

/// The production implementation of the fetch side (CK-R5). The gateway calls `commit` per batch and `saveEngineState` for the
/// state that follows it. For every record:
///
/// 1. decode and validate the structure (`CloudRecordCodec`); anything this build cannot fully understand is quarantined with its
///    raw fields and every asset pinned, and fences its entity;
/// 2. a valid `Entity` has its payload asset (if any) pinned durably and is stored as the latest version per record name
///    (`CloudSyncStore.storeRemote`: ordering by `ver` within an incarnation, echoes are no-ops, divergent content is quarantined);
/// 3. a newer valid version of a quarantined entity releases that quarantine (the fence lifts, the pinned files go);
/// 4. a `BlobPart` is skipped entirely (fetched by name later, never stored, pinned or quarantined); the `KeyBundle` goes to its handler.
///
/// A copy failure (disk full, source already evicted, hash mismatch) throws out of `commit`: the gateway saves no state, the token
/// does not advance and the record is redelivered. Each record is stored in its own transaction; a batch that fails halfway has
/// stored a prefix and the redelivery finds it as echoes (idempotent), so the outcome equals one transaction per batch.
///
/// Every store write carries the account generation this sink was created for, so a batch delivered after an account change
/// stores nothing (CK-R15, CK-R98). It also passes the generation to `saveEngineState`.
public final class CloudFeedSink: CloudChangeSink, CloudRemoteIntake, @unchecked Sendable {
    public typealias KeyBundleHandler = @Sendable (CloudKeyBundleHeader) throws -> Void

    private let store: CloudSyncStore
    private let pinner: CloudAssetPinner
    private let crash: CrashPoint
    private let generation: @Sendable () throws -> Int64
    private let clock: @Sendable () -> Date
    private let decode: @Sendable (CloudRecord) throws -> CloudDecodedRecord
    private let onKeyBundle: KeyBundleHandler
    private let onUnreadableKeyBundle: @Sendable () -> Void
    private let lock = NSLock()
    private var full = false
    private var delivered = Set<String>()
    private var withheld = false

    /// - Parameters:
    ///   - generation: the account generation of the fetch; the default reads the current one at every call, a coordinator passes
    ///     the one captured when the fetch started (`CloudGenerationFence.run`).
    ///   - decode: the record decoder of this build (a test teaches a newer version through it).
    public init(store: CloudSyncStore, pinner: CloudAssetPinner, crash: CrashPoint = .never,
                generation: (@Sendable () throws -> Int64)? = nil, clock: @escaping @Sendable () -> Date = { Date() },
                decode: @escaping @Sendable (CloudRecord) throws -> CloudDecodedRecord = { try CloudRecordCodec.decode($0) },
                onKeyBundle: @escaping KeyBundleHandler = { _ in },
                onUnreadableKeyBundle: @escaping @Sendable () -> Void = {}) {
        self.onUnreadableKeyBundle = onUnreadableKeyBundle
        self.store = store; self.pinner = pinner; self.crash = crash; self.clock = clock; self.decode = decode; self.onKeyBundle = onKeyBundle
        self.generation = generation ?? { try store.generation() }
    }

    public var isInFullRefetch: Bool { lock.withLock { full } }

    // MARK: CloudChangeSink

    public func commit(changed: [CloudRecord], deletedNames: [String]) throws {
        let delivery: CloudDelivery = lock.withLock { full ? .fullRefetch : .incremental }
        do {
            for record in changed {
                try crash.hit("sink.beforeRecord")
                _ = try intake(record, delivery: delivery)
                if delivery == .fullRefetch { lock.withLock { _ = delivered.insert(record.name) } }
                try crash.hit("sink.afterRecord")
            }
            for name in deletedNames { try recordDeletion(of: name) }
            lock.withLock { withheld = false }
        } catch {
            lock.withLock { withheld = true; full = false; delivered = [] }
            throw error
        }
    }

    public func saveEngineState(_ state: Data) throws {
        if lock.withLock({ withheld }) { throw CloudSinkError.stateWithheld }
        try crash.hit("sink.beforeStateSave")
        try store.saveEngineState(state, accountGeneration: try generation())
    }

    public func beginFullRefetch() throws {
        if case .removed = try store.zoneState() { throw CloudSinkError.zoneRemoved }
        lock.withLock { full = true; delivered = []; withheld = false }
    }

    /// The fetch returned the cloud's whole current picture. Every entity we hold a base pair for that it did not return, and
    /// that is not quarantined, is paused with its local content untouched (CK-R5). Nothing is republished.
    public func endFullRefetch() throws {
        let names = lock.withLock { () -> Set<String> in let taken = delivered; full = false; delivered = []; return taken }
        let quarantined = try store.quarantinedRecordNames()
        let gen = try generation()
        for entity in try store.pairedEntities() where !names.contains(entity.recordName) && !quarantined.contains(entity.recordName) {
            if try store.missing(entityType: entity.entityType, entityId: entity.entityId) != nil { continue }
            if try store.isRecovering(entity) { continue }                  // its create-only snapshot has not gone out yet
            try store.markMissing(entityType: entity.entityType, entityId: entity.entityId, reason: "notReturnedByFullRefetch", accountGeneration: gen)
        }
    }

    // MARK: one record

    @discardableResult
    public func intake(_ record: CloudRecord, delivery: CloudDelivery) throws -> CloudIntakeOutcome {
        // A BlobPart is never stored, pinned or quarantined here: its metadata and asset are fetched by name when the attachment
        // needs it (`CloudKitBlobTransfer.download(hash:)`).
        if record.type == .blobPart { return .echo }
        let gen = try generation()
        let decoded: CloudDecodedRecord
        do { decoded = try decode(record) } catch {
            // A key bundle this build cannot read still counts as a changed key bundle: data work waits for its verification (CK-R135).
            if record.type == .keyBundle { onUnreadableKeyBundle() }
            return try quarantineUnreadable(record, reason: Self.reason(error), generation: gen)
        }
        switch decoded {
        case .blobPart: return .echo
        case .keyBundle(let header):
            try onKeyBundle(header)
            return .stored
        case .entity(let header):
            return try accept(record, header: header, delivery: delivery, generation: gen)
        }
    }

    private func accept(_ record: CloudRecord, header: CloudEntityHeader, delivery: CloudDelivery, generation gen: Int64) throws -> CloudIntakeOutcome {
        guard let systemFields = record.systemFields else { throw CloudIntakeError.missingSystemFields(record.name) }
        var pinned: [CloudPinnedAsset] = []
        var sealed: Data?, sealedPath: String?, sealedSha256: String?
        switch header.payload {
        case .inline(let data): sealed = data
        case .asset:
            pinned = try pinner.pin(record)
            guard let asset = pinned.first else { throw CloudIntakeError.pinMismatch(record.name) }
            sealedPath = asset.path; sealedSha256 = asset.sha256
        }
        try crash.hit("sink.afterPin")
        let raw = try Self.stableRaw(record, pinned: pinned)
        let version = CloudRemoteVersion(entity: CloudEntityRef(entityType: header.entityType.rawValue, entityId: header.entityId),
                                         inc: header.inc, incs: header.incs, ver: header.ver, sid: header.sid, sids: header.sids,
                                         systemFields: systemFields, sealed: sealed, sealedPath: sealedPath, sealedSha256: sealedSha256,
                                         blobRefs: header.blobs, receivedAt: clock(), rawFields: raw, pinnedAssets: pinned)
        let outcome: CloudStoreRemoteOutcome
        do { outcome = try store.storeRemote(version, delivery: delivery, accountGeneration: gen) } catch {
            pinner.remove(pinned.map(\.path)); throw error
        }
        switch outcome {
        case .stored:
            // A quarantine is NOT released here, on the strength of a header: the receiver releases it in the transaction that
            // applies a newer version after that version was opened and validated (`CloudReconciler`).
            return .stored
        case .echo: pinner.remove(pinned.map(\.path)); return .echo
        case .ignoredStale: pinner.remove(pinned.map(\.path)); return .ignoredStale
        case .ignoredSupersededIncarnation: pinner.remove(pinned.map(\.path)); return .ignoredSupersededIncarnation
        case .quarantinedDivergent(let obsolete): pinner.remove(obsolete); return .quarantined
        }
    }

    private func quarantineUnreadable(_ record: CloudRecord, reason: String, generation gen: Int64) throws -> CloudIntakeOutcome {
        // Every asset of the record is pinned, except a BlobPart's: those are fetched by name when they are needed.
        // The same record delivered again after the person chose to ignore it is not pinned again: its row says ignored.
        if record.type != .blobPart, let existing = try store.quarantineRow(recordName: record.name), existing.ignoredByUser,
           existing.rawFields == (try Self.stableRaw(record, digests: try Self.assetDigests(record))) { return .quarantined }
        let pinned = record.type == .blobPart ? [] : try pinner.pin(record)
        do {
            let obsolete = try store.quarantine(record: CloudQuarantineRecord(recordName: record.name, reason: reason, v: CloudBasicRemoteIntake.version(of: record),
                                                                               rawFields: try Self.stableRaw(record, pinned: pinned)),
                                                pinned: pinned, accountGeneration: gen)
            pinner.remove(obsolete)
        } catch { pinner.remove(pinned.map(\.path)); throw error }
        return .quarantined
    }

    /// The record as JSON with every asset URL replaced by the digest of its content: a URL names a staging file that changes with
    /// every delivery, and two deliveries of the same record must compare equal (the "ignored" mark depends on it).
    static func stableRaw(_ record: CloudRecord, pinned: [CloudPinnedAsset]) throws -> Data {
        try stableRaw(record, digests: Dictionary(uniqueKeysWithValues: pinned.map { ($0.field, $0.sha256) }))
    }
    static func stableRaw(_ record: CloudRecord, digests: [String: String]) throws -> Data {
        var copy = record
        for (field, value) in record.fields { if case .asset = value { copy.fields[field] = .string("asset:\(digests[field] ?? "")") } }
        return try CloudBasicRemoteIntake.rawFields(copy)
    }
    static func assetDigests(_ record: CloudRecord) throws -> [String: String] {
        var out: [String: String] = [:]
        for (field, value) in record.fields { if case .asset(let url) = value { out[field] = CloudSyncStore.sha256Hex(try Data(contentsOf: url)) } }
        return out
    }

    static func reason(_ error: Error) -> String {
        if case CloudRecordRejection.unsupported(let reason) = error { return reason.code }
        return "undecodable"
    }

    // MARK: retry from the quarantine

    /// Decodes a quarantined record again under this build, from its pinned copies (never from the staging area, which the system
    /// empties). A record that is now understood becomes an ordinary stored version and the quarantine row goes, together with the
    /// pinned files nothing references any more. Returns `true` when the row was released.
    func retryQuarantined(_ row: CloudQuarantineRow, pinned pins: [CloudPinnedAsset]) throws -> Bool {
        guard var record = try? JSONDecoder().decode(CloudRecord.self, from: row.rawFields) else { return false }
        for pin in pins {
            _ = try pinner.verify(pin)
            record.fields[pin.field] = .asset(pinner.url(for: pin.path))
        }
        let decoded: CloudDecodedRecord
        do { decoded = try decode(record) } catch { return false }
        let gen = try generation()
        switch decoded {
        case .blobPart: break
        case .keyBundle(let header): try onKeyBundle(header)
        case .entity(let header):
            guard let systemFields = record.systemFields else { return false }
            var sealed: Data?, sealedPath: String?, sealedSha256: String?
            switch header.payload {
            case .inline(let data): sealed = data
            case .asset:
                guard let pin = pins.first(where: { $0.field == "cipherAsset" }) else { return false }
                sealedPath = pin.path; sealedSha256 = pin.sha256
            }
            let version = CloudRemoteVersion(entity: CloudEntityRef(entityType: header.entityType.rawValue, entityId: header.entityId), inc: header.inc,
                                             incs: header.incs, ver: header.ver, sid: header.sid, sids: header.sids, systemFields: systemFields, sealed: sealed,
                                             sealedPath: sealedPath, sealedSha256: sealedSha256, blobRefs: header.blobs, receivedAt: clock(),
                                             rawFields: row.rawFields, pinnedAssets: pins)
            switch try store.storeRemote(version, delivery: .serverRecordChanged, accountGeneration: gen) {
            case .quarantinedDivergent: return false
            case .stored:
                // Understood structurally, not yet opened: the quarantine row stays and fences the entity until the receiver has
                // authenticated, validated and applied this very version (`CloudReconciler`), which releases it atomically.
                return true
            case .echo, .ignoredStale, .ignoredSupersededIncarnation: break      // already covered by an applied version
            }
        }
        pinner.remove(try store.releaseQuarantine(recordName: row.recordName, matchingRaw: row.rawFields, accountGeneration: gen))
        return true
    }

    // MARK: deletions seen in the feed

    /// A record the cloud reports as deleted (by hand in the Console, or lost): the entity pauses, local content stays (CK-R5).
    private func recordDeletion(of name: String) throws {
        guard let entity = CloudEntityRef.parse(recordName: name),
              try store.pair(for: entity) != nil,
              try store.missing(entityType: entity.entityType, entityId: entity.entityId) == nil,
              try !store.isRecovering(entity) else { return }
        try store.markMissing(entityType: entity.entityType, entityId: entity.entityId, reason: "deletedInCloud", accountGeneration: try generation())
    }
}
