// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// The publisher (CK-R4, CK-R5 fence, CK-R15, CK-R21): local edits to sealed records, and the outcome of every save.
//
//   sync_dirty (journal, one row per entity, generation counter)
//     -> prepare: snapshot + seal + one ck_inflight row, in ONE transaction (immutable afterwards)
//     -> blobs first (Task 7 seam), then state `sending` is written, then gateway.submit
//     -> ck_send_result rows (written by the gateway the moment an outcome is known) are consumed here
//     -> recordSaved | merge request (the receiver merges) | unknown-outcome resolution (CloudOutcomeResolver)
//
// Invariants this file keeps and never works around:
// - I1: a save is built only from the base pair of the entity (its change tag and the ancestor of that same version).
//   No code path takes a change tag from a fetch to retry a send; a fetched version only becomes a base pair through the
//   receiver's applied merge, and a cloud version found by name is stored as a fetched version, never as a base.
// - I3: `recordSaved` clears the dirty generation the snapshot covered, never a higher one.
// - Nothing is deleted: not a dirty row, not an in-flight snapshot (except by the receiver, after it merged), not a record.

/// The blob half of a publish (Task 7: `CloudKitBlobTransfer`). The publisher calls it before it submits an entity that
/// references blobs and submits nothing for the entity if it throws.
public protocol CloudBlobUploading: Sendable {
    /// Makes every blob ciphertext named by `hashes` present and verified in the cloud.
    func ensureUploaded(_ hashes: [String]) async throws
}

public struct CloudPublishReport: Sendable, Equatable {
    public var prepared = 0
    /// Saves handed to the gateway.
    public var submitted = 0
    /// Saves recorded as landed (`recordSaved`).
    public var saved = 0
    /// Snapshots that go out again (the save did not land, or could not be sent).
    public var requeued = 0
    /// Snapshots that stay because iCloud has no room for them (a subset of `requeued`): the person is told (`quotaFull`).
    public var quotaHeld = 0
    /// A cloud version waits in `ck_remote`; the receiver merges it (base: `CloudOutcomeResolver.mergeBase`).
    public var needsMerge: [CloudEntityRef] = []
    public var paused: [CloudEntityRef] = []
    /// Not sent now: fenced, paused, waiting for a merge, or its blobs are not ready.
    public var blocked: [CloudEntityRef] = []
    /// Results of an older account generation, discarded (CK-R15).
    public var discardedStaleResults = 0
    /// Saves that landed while a fetched version had already advanced the pair: nothing written, nothing cleared, snapshot dropped.
    public var advanced: [CloudEntityRef] = []

    public init() {}

    mutating func absorb(_ other: CloudPublishReport) {
        prepared += other.prepared; submitted += other.submitted; saved += other.saved; requeued += other.requeued; quotaHeld += other.quotaHeld
        needsMerge += other.needsMerge; paused += other.paused; blocked += other.blocked; advanced += other.advanced
        discardedStaleResults += other.discardedStaleResults
    }
}

public enum CloudPublisherError: Error, Equatable {
    case invalidRecord(String)
    /// The key-readiness gate is closed (key creation is not complete): nothing is prepared or submitted.
    case keysNotReady
    /// A `submit` failed and some of its rows could not be marked `unknown` (even after one retry): the cycle must not carry on as if they were.
    case unknownNotRecorded(attempts: [String], cause: String)
}

public struct CloudPublisher: Sendable {
    private let database: AppDatabase
    private let store: CloudSyncStore
    private let gateway: any CloudKitGateway
    private let sealer: CloudPayloadSealer
    private let accountID: String
    private let vaultKey: SymmetricKey
    private let blobs: any CloudBlobUploading
    private let intake: any CloudRemoteIntake
    private let crash: CrashPoint
    private let clock: @Sendable () -> Date
    private let assetDirectory: URL
    private let attachments: CloudAttachmentPreparer
    private let keyReadiness: @Sendable () throws -> Void

    /// - Parameters:
    ///   - assetDirectory: where a sealed payload over 200 KiB is written for the one save that carries it as an asset.
    ///   - intake: how a cloud version found by name or inside a conflict is stored (the receiver's sink in production).
    ///   - keyReadiness: called before anything is prepared or submitted; it throws while key creation is incomplete, because no
    ///     `Entity` or `BlobPart` may be saved before then (CK-R14: a lost key-creation race would leave data under a key nobody
    ///     shares). The error reaches the caller; dirty generations and prepared snapshots stay exactly as they are. Deliberately
    ///     required: the coordinator wires it to the key layer, and a publisher with no gate must be a visible choice (`{}`).
    public init(database: AppDatabase, paths: AppPaths, store: CloudSyncStore, gateway: any CloudKitGateway,
                accountID: String, vaultKey: SymmetricKey, blobs: any CloudBlobUploading, intake: any CloudRemoteIntake,
                keyReadiness: @escaping @Sendable () throws -> Void, assetDirectory: URL? = nil, crash: CrashPoint = .never, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.store = store; self.gateway = gateway; self.accountID = accountID; self.vaultKey = vaultKey
        self.sealer = CloudPayloadSealer(accountID: accountID, vaultKey: vaultKey)
        self.blobs = blobs; self.intake = intake; self.keyReadiness = keyReadiness; self.crash = crash; self.clock = clock
        self.assetDirectory = assetDirectory ?? paths.root.appendingPathComponent("CloudSendStaging", isDirectory: true)
        self.attachments = CloudAttachmentPreparer(database: database, preparer: SyncAttachmentPreparer(database: database, paths: paths, accountID: accountID, vaultKey: vaultKey))
    }

    // MARK: lifecycle

    /// Call once at launch: a send that was `sending` when the process ended may or may not have landed, so it becomes
    /// `unknown` and the CK-R4 table decides.
    @discardableResult
    public func treatSendingAsUnknown() throws -> Int { try store.interruptSending() }

    /// One pass in the order that matters: results first (they may free an entity), then ambiguous outcomes, then new work.
    public func publishCycle() async throws -> CloudPublishReport {
        var report = try consumeResults()
        report.absorb(try await resolveAmbiguous())
        report.prepared += try await prepare().count
        report.absorb(try await submit())
        report.absorb(try consumeResults())
        return report
    }

    /// Uploads are allowed once the library is bound to this account on the CloudKit backend and sync is enabled
    /// (the first-run step of Task 10 sets `enabled`); never while the account is fenced.
    func isOpen() throws -> Bool {
        let open = try database.pool.read { db -> Bool in
            guard let row = try Row.fetchOne(db, sql: "SELECT backend, accountId, enabled FROM sync_control WHERE id=1") else { return false }
            return (row["backend"] as String?) == SyncBackend.cloudkit.rawValue && (row["accountId"] as String?) == accountID && (row["enabled"] as Bool?) == true
        }
        return try open && !store.isAccountFenced()
    }

    // MARK: prepare

    /// Snapshots dirty entities into immutable in-flight rows. Order is the Cloudflare engine's: key bundle, attachments,
    /// then notes and the rest. Skipped without losing anything: an entity that is fenced by a quarantine, paused after its
    /// record went missing, already in flight, or waiting for a fetched version to be merged. Their dirty generations keep
    /// rising with every edit and are published later on the right base.
    @discardableResult
    public func prepare(limit: Int = 100) async throws -> [CloudInflight] {
        guard try isOpen() else { return [] }
        try keyReadiness()
        try await attachments.preparePending(limit: limit)
        let candidates = try dirtyCandidates()
        var made: [CloudInflight] = []
        for candidate in candidates where made.count < limit {
            guard let type = SyncEntityType(rawValue: candidate.type) else { throw SyncProtocolError.unsupportedVersion }
            if let attempt = try prepareOne(type: type, localID: candidate.localID) {
                made.append(attempt)
                try crash.hit("publisher.afterPrepare")
            }
        }
        return made
    }

    private func dirtyCandidates() throws -> [(type: String, localID: String)] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT entityType,localId FROM sync_dirty
                ORDER BY CASE entityType WHEN 'keyBundle' THEN 0 WHEN 'attachment' THEN 1 ELSE 2 END,entityType,localId
                """).map { (type: $0["entityType"] as String, localID: $0["localId"] as String) }
        }
    }

    /// Fenced by a quarantine, paused after its record went missing, or a fetched version waits for the receiver's merge.
    private func isBlocked(_ entity: CloudEntityRef) throws -> Bool {
        try database.pool.read { db in
            try CloudSyncStore.isFenced(db, entity) || CloudSyncStore.isPaused(db, entity) || CloudSyncStore.hasPendingRemote(db, entity)
        }
    }

    private func prepareOne(type: SyncEntityType, localID: String) throws -> CloudInflight? {
        try database.pool.write { db in
            // Re-read inside the transaction: the generation in the snapshot is the generation of this very content.
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_dirty WHERE entityType=? AND localId=?", arguments: [type.rawValue, localID])
            else { return nil }
            let dirty = SyncDirty(type: type, localID: localID, generation: row["generation"], tombstone: row["tombstone"])
            let entityID = try CloudPayloadSealer.entityID(for: dirty, vaultKey: vaultKey, in: db)
            let entity = CloudEntityRef(entityType: type.rawValue, entityId: entityID)
            if try CloudSyncStore.isFenced(db, entity) || CloudSyncStore.isPaused(db, entity) || CloudSyncStore.hasPendingRemote(db, entity) { return nil }
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ck_inflight WHERE entityType=? AND entityId=?)",
                                 arguments: [entity.entityType, entity.entityId]) == true { return nil }
            let content: SyncContent
            do { content = try CloudPayloadSealer.capture(dirty, accountID: accountID, vaultKey: vaultKey, in: db) }
            catch SyncQueueError.snapshotUnavailable { return nil }
            let pair = try CloudSyncStore.pair(db, entity)
            let attemptId = UUIDv7.make()
            let attempt = CloudInflight(
                entity: entity, localId: localID, generation: dirty.generation, attemptId: attemptId,
                baseSystemFields: pair?.systemFields, baseAncestor: pair?.ancestor, baseVer: pair?.ver ?? 0,
                inc: pair?.inc ?? Self.newIncarnation(),
                sealed: try sealer.seal(content, type: type, entityID: entityID, deletedAt: clock()),
                blobRefs: content.blobRefs, state: .prepared, accountGeneration: try CloudSyncStore.generation(db),
                preparedAt: clock(), sids: Array(([attemptId] + (pair?.sids ?? [])).prefix(CloudRecordCodec.maxAttemptHistory)))
            try CloudSyncStore.insertInflight(db, attempt)
            return attempt
        }
    }

    /// 128 random bits, base64url without padding (CK-R21).
    static func newIncarnation() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: submit

    /// Sends every prepared snapshot: blobs first, then state `sending`, then `gateway.submit`. A failing blob upload keeps
    /// that entity prepared and sends nothing for it. If `submit` throws, the rows it was handed become `unknown` (the
    /// intent may be durable in the gateway), except for an injected crash, which leaves them `sending` like a real one.
    public func submit() async throws -> CloudPublishReport {
        var report = CloudPublishReport()
        guard try isOpen() else { return report }
        try keyReadiness()
        let generation = try store.generation()
        // Phase 1 awaits (blob uploads). Whatever it looked at may change meanwhile, so it only decides what is worth trying.
        var ready: [CloudInflight] = []
        for attempt in try store.allInflight() where attempt.state == .prepared && attempt.accountGeneration == generation {
            if try isBlocked(attempt.entity) { report.blocked.append(attempt.entity); continue }
            if !attempt.blobRefs.isEmpty {
                do { try await blobs.ensureUploaded(attempt.blobRefs) } catch is CancellationError { throw CancellationError() } catch let injected as CrashInjected { throw injected } catch {
                    report.blocked.append(attempt.entity); continue
                }
            }
            ready.append(attempt)
        }
        // Phase 2 has no await until the gateway is called: each snapshot is revalidated and marked `sending` in one store step.
        var saves: [CloudSave] = []
        for attempt in ready {
            do { try store.beginSending(attemptId: attempt.attemptId) }
            catch CloudSyncStoreError.pairAdvanced {
                // Never sent, and its base is gone: drop it; the dirty generations make the next snapshot on the new pair.
                try store.discardInflight(attemptId: attempt.attemptId)
                report.blocked.append(attempt.entity); continue
            } catch CloudSyncStoreError.entityFenced { report.blocked.append(attempt.entity); continue }
            catch CloudSyncStoreError.entityPaused { report.blocked.append(attempt.entity); continue }
            catch CloudSyncStoreError.entityMergePending { report.blocked.append(attempt.entity); continue }
            let record: CloudRecord
            do { record = try buildRecord(attempt) } catch CloudPublisherError.invalidRecord {
                try store.markInflight(attemptId: attempt.attemptId, state: .prepared)
                report.blocked.append(attempt.entity); continue
            }
            try crash.hit("publisher.afterSending")
            saves.append(CloudSave(attemptId: attempt.attemptId, accountGeneration: attempt.accountGeneration, record: record))
        }
        guard !saves.isEmpty else { return report }
        do { try await gateway.submit(saves) } catch let injected as CrashInjected { throw injected } catch {
            // The rows go to `unknown` so that the restart path resolves them. If that fails (once more after a retry) the cycle reports
            // it: carrying on would leave rows `sending` that nobody resolves until the next launch. A row that is already gone needs no mark.
            var unmarked: [String] = []
            for save in saves {
                do { try store.markInflight(attemptId: save.attemptId, state: .unknown) }
                catch CloudSyncStoreError.unknownAttempt { continue }
                catch { unmarked.append(save.attemptId) }
            }
            var stillUnmarked: [String] = []
            for attemptId in unmarked {
                do { try store.markInflight(attemptId: attemptId, state: .unknown) }
                catch CloudSyncStoreError.unknownAttempt { continue }
                catch { stillUnmarked.append(attemptId) }
            }
            if !stillUnmarked.isEmpty { throw CloudPublisherError.unknownNotRecorded(attempts: stillUnmarked, cause: "\(error)") }
            throw error
        }
        report.submitted = saves.count
        try crash.hit("publisher.afterSubmit")
        return report
    }

    /// The record for one in-flight row, from the row and the base pair alone: `ver = baseVer + 1`, `sid = attemptId`,
    /// the chain the row carries, `inc` of the snapshot and the last 4 superseded ids. A first publish (no base tag) is a
    /// create. A sealed payload over 200 KiB travels as an asset of the same record.
    func buildRecord(_ attempt: CloudInflight) throws -> CloudRecord {
        guard let type = SyncEntityType(rawValue: attempt.entity.entityType) else { throw CloudPublisherError.invalidRecord(attempt.entity.recordName) }
        let pair = try store.pair(for: attempt.entity)
        var incs: [String] = []
        if let pair {
            incs = pair.inc == attempt.inc ? pair.supersededIncs : CloudSyncStore.cap([pair.inc] + pair.supersededIncs, CloudRecordCodec.maxIncarnationHistory, excluding: attempt.inc)
        }
        let payload: CloudEntityPayload
        if attempt.sealed.count <= CloudRecordCodec.maxInlineCipherBytes { payload = .inline(attempt.sealed) } else {
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            let file = assetDirectory.appendingPathComponent(attempt.attemptId + ".cipher")
            if (try? Data(contentsOf: file)) != attempt.sealed { try attempt.sealed.write(to: file, options: .atomic) }
            payload = .asset(file)
        }
        let header = CloudEntityHeader(entityType: type, entityId: attempt.entity.entityId, inc: attempt.inc,
                                       incs: Array(incs.prefix(CloudRecordCodec.maxIncarnationHistory)), ver: attempt.baseVer + 1,
                                       sid: attempt.attemptId, sids: attempt.sids, payload: payload, blobs: attempt.blobRefs)
        var record = CloudRecordCodec.encode(header)
        record.systemFields = attempt.baseSystemFields
        // The format is validated on the way out as strictly as on the way in.
        do { _ = try CloudRecordCodec.decode(record) } catch { throw CloudPublisherError.invalidRecord(attempt.entity.recordName) }
        return record
    }

    // MARK: results

    /// Consumes every `ck_send_result` row (idempotent by attempt id). A result of an older account generation is
    /// discarded; the snapshot stays and is resolved by the outcome table when its account returns (CK-R15).
    @discardableResult
    public func consumeResults() throws -> CloudPublishReport {
        var report = CloudPublishReport()
        let generation = try store.generation()
        for attempt in try store.allInflight() {
            guard let result = try store.sendResult(attemptId: attempt.attemptId) else { continue }
            guard result.accountGeneration == generation, attempt.accountGeneration == generation else {
                try store.deleteSendResult(attemptId: attempt.attemptId)
                report.discardedStaleResults += 1
                continue
            }
            try crash.hit("publisher.afterResultStored")
            try settle(attempt, outcome: result.outcome, report: &report)
        }
        try store.deleteOrphanSendResults()
        sweepAssets()
        return report
    }

    private func settle(_ attempt: CloudInflight, outcome: CloudSaveOutcome, report: inout CloudPublishReport) throws {
        switch outcome {
        case .saved(let systemFields):
            try recordLanded(attempt, systemFields: systemFields, report: &report)
        case .serverRecordChanged(let server):
            try resolve(attempt, server: server, serverChanged: true, report: &report)
        case .unknownItem:
            // A base was held and the record is not there (CK-R5): pause. Without a base the create cannot be "unknown".
            if attempt.baseSystemFields != nil { try pause(attempt, reason: "unknownItem", report: &report) }
            else { try requeue(attempt, report: &report) }
        case .quotaExceeded, .limitExceeded, .zoneNotFound, .unauthenticated, .fenced:
            // Definitely not saved: the snapshot is still valid and goes out again when the obstacle is gone.
            if case .quotaExceeded = outcome { report.quotaHeld += 1 }
            try requeue(attempt, report: &report)
        case .offline, .failed:
            // The request may have landed before the failure was reported: only the cloud can say.
            try store.markInflight(attemptId: attempt.attemptId, state: .unknown)
            try store.deleteSendResult(attemptId: attempt.attemptId)
        }
    }

    private func recordLanded(_ attempt: CloudInflight, systemFields: Data, report: inout CloudPublishReport) throws {
        do {
            let recorded = try store.recordSaved(attemptId: attempt.attemptId, newSystemFields: systemFields)
            switch recorded {
            case .recorded: report.saved += 1
            case .alreadyRecorded: break
            case .pairAdvanced:
                try settleAdvanced(attempt, savedSystemFields: systemFields, report: &report)
            }
            try crash.hit("publisher.afterRecordSaved")
        } catch CloudSyncStoreError.entityFenced {
            // A newer unreadable version arrived meanwhile and fences the entity: our tag must not become a base pair now.
            // The snapshot becomes `unknown` and is resolved against the cloud after the fence lifts.
            try store.markInflight(attemptId: attempt.attemptId, state: .unknown)
            try store.deleteSendResult(attemptId: attempt.attemptId)
            report.blocked.append(attempt.entity)
        }
    }

    /// The save landed, but the pair is no longer the base it was built on (a fetched version was applied while it was in
    /// flight). Nothing is written to the pair and no dirty generation is cleared. The snapshot is dropped only when the
    /// applied pair provably descends from it: same incarnation and our attempt id in its chain. Otherwise the landed
    /// version becomes a merge input (a fetched version for the receiver, merged through the existing path with
    /// `CloudOutcomeResolver.mergeBase` and `conflictIdentity`) and the snapshot stays until that merge ran.
    private func settleAdvanced(_ attempt: CloudInflight, savedSystemFields: Data, report: inout CloudPublishReport) throws {
        if let pair = try store.pair(for: attempt.entity), pair.inc == attempt.inc, pair.sids.contains(attempt.attemptId) {
            try store.discardInflight(attemptId: attempt.attemptId)
            report.advanced.append(attempt.entity)
            return
        }
        // The version our save created, as the cloud holds it (or held it): its superseded-incarnation list is not known
        // here and stays empty; the receiver adds the incarnation it replaces when it adopts the version.
        let landed = CloudRemoteVersion(entity: attempt.entity, inc: attempt.inc, ver: attempt.baseVer + 1, sid: attempt.attemptId, sids: attempt.sids,
                                        systemFields: savedSystemFields, sealed: attempt.sealed, blobRefs: attempt.blobRefs, receivedAt: clock())
        switch try store.storeRemote(landed, delivery: .serverRecordChanged) {
        case .stored:
            try store.markInflight(attemptId: attempt.attemptId, state: .unknown)
            try store.deleteSendResult(attemptId: attempt.attemptId)
            report.needsMerge.append(attempt.entity)
        case .quarantinedDivergent:
            // Two different payloads for one version: fenced like any divergent record, snapshot kept.
            try store.markInflight(attemptId: attempt.attemptId, state: .unknown)
            try store.deleteSendResult(attemptId: attempt.attemptId)
            report.blocked.append(attempt.entity)
        case .echo, .ignoredStale, .ignoredSupersededIncarnation:
            // The pair already covers this version (an older or equal one of the same history): nothing to merge; whatever
            // the applied merge left different from the cloud is still dirty and goes out on the pair as it is.
            try store.discardInflight(attemptId: attempt.attemptId)
            report.advanced.append(attempt.entity)
        }
    }

    private func requeue(_ attempt: CloudInflight, report: inout CloudPublishReport) throws {
        try store.markInflight(attemptId: attempt.attemptId, state: .prepared)
        try store.deleteSendResult(attemptId: attempt.attemptId)
        report.requeued += 1
    }

    private func pause(_ attempt: CloudInflight, reason: String, report: inout CloudPublishReport) throws {
        // Keep everything: the snapshot (`unknown`), the dirty generations and the library content. Only the pause is new.
        try store.markMissing(entityType: attempt.entity.entityType, entityId: attempt.entity.entityId, reason: reason)
        try store.markInflight(attemptId: attempt.attemptId, state: .unknown)
        try store.deleteSendResult(attemptId: attempt.attemptId)
        report.paused.append(attempt.entity)
    }

    // MARK: ambiguous outcomes (CK-R4)

    /// Resolves every `unknown` snapshot against the cloud: fetch the record by name, then the six rows of the table.
    /// Offline or unauthenticated leaves them for the next cycle.
    public func resolveAmbiguous() async throws -> CloudPublishReport {
        var report = CloudPublishReport()
        let generation = try store.generation()
        var targets: [CloudInflight] = []
        for attempt in try store.allInflight() where attempt.state == .unknown && attempt.accountGeneration == generation {
            if try isBlocked(attempt.entity) { report.blocked.append(attempt.entity); continue }
            if try store.sendResult(attemptId: attempt.attemptId) != nil { continue }   // consumed first
            targets.append(attempt)
        }
        guard !targets.isEmpty else { return report }
        let fetched: [String: CloudRecord]
        do { fetched = try await gateway.fetch(targets.map(\.entity.recordName), keys: nil) } catch is CloudSyncError { return report }
        for attempt in targets {
            try resolve(attempt, server: fetched[attempt.entity.recordName], serverChanged: false, report: &report)
        }
        return report
    }

    /// Executes `CloudOutcomeResolver.decide` for one snapshot.
    private func resolve(_ attempt: CloudInflight, server: CloudRecord?, serverChanged: Bool, report: inout CloudPublishReport) throws {
        var header: CloudEntityHeader?
        if let server {
            do {
                guard case .entity(let decoded) = try CloudRecordCodec.decode(server) else { throw CloudIntakeError.notAnEntity(server.name) }
                header = decoded
            } catch CloudRecordRejection.unsupported {
                // A newer or damaged version: quarantine it (the entity is fenced), keep the snapshot, decide later.
                _ = try intake.intake(server, delivery: .serverRecordChanged)
                try store.markInflight(attemptId: attempt.attemptId, state: .unknown)
                try store.deleteSendResult(attemptId: attempt.attemptId)
                report.blocked.append(attempt.entity)
                return
            }
        }
        let pair = try store.pair(for: attempt.entity)
        var decision = CloudOutcomeResolver.decide(attempt: attempt, pair: pair, server: header, serverSystemFields: server?.systemFields,
                                                   serverChanged: serverChanged)
        // The cloud itself said the base is stale, so "resend" and "pause" cannot be right; merge.
        if serverChanged, decision == .resendSameSnapshot || decision == .pauseEntity { decision = .mergeConservatively }
        switch decision {
        case .resendSameSnapshot:
            try requeue(attempt, report: &report)
        case .pauseEntity:
            if pair == nil { try requeue(attempt, report: &report) } else { try pause(attempt, reason: "ambiguousSaveRecordAbsent", report: &report) }
        case .saveLanded(let systemFields):
            try recordLanded(attempt, systemFields: systemFields, report: &report)
        case .landedThenOverwritten, .mergeConservatively:
            guard let server else { try requeue(attempt, report: &report); return }
            let outcome = try intake.intake(server, delivery: .serverRecordChanged)
            try store.markInflight(attemptId: attempt.attemptId, state: .unknown)
            try store.deleteSendResult(attemptId: attempt.attemptId)
            if try store.hasPendingRemote(attempt.entity) { report.needsMerge.append(attempt.entity) }
            else if outcome == .quarantined { report.blocked.append(attempt.entity) }
        }
    }

    // MARK: housekeeping

    /// Removes asset files of sealed payloads whose snapshot is gone.
    private func sweepAssets() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: assetDirectory, includingPropertiesForKeys: nil) else { return }
        let live = Set((try? store.inflightAttemptIds()) ?? [])
        for file in files where !live.contains(file.deletingPathExtension().lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }
}
