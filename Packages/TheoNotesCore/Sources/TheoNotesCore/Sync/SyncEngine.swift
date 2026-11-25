// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

public struct SyncRunSummary: Sendable, Equatable {
    public var uploaded = 0
    public var downloaded = 0
    public var applied = 0
    /// Dirty work excluding attachments without accessible source or a prepared upload.
    public var pendingUploads = 0
    /// Retained dirty attachments whose source is unavailable on this device.
    public var unavailableAttachments = 0
    public var pendingDownloads = 0
    public var waitingForUnlock = 0
    /// Dependencies in the final materialization pass that require a local upload receipt.
    public var waitingForUploads = 0
    /// Conflicting mutations still queued after reconciliation in this run.
    public var deferredConflicts = 0
    public var passwordRefreshRequired = false

    /// Drain productive batches promptly, but leave unavailable files/dependencies queued
    /// for the ordinary poll or a local-change/connectivity wake instead of a tight loop.
    public var shouldContinueSoon: Bool {
        (pendingUploads > 0 || pendingDownloads > 0) && (uploaded > 0 || downloaded > 0 || applied > 0)
    }
}

/// One serialized sync cycle shared by foreground and background callers. The caller flushes
/// editor journals before invoking it and refreshes open sessions after receiving the summary.
/// Cancellation leaves both immutable uploads and received ciphertext durable for the next run.
public actor SyncEngine {
    private let database: AppDatabase
    private let paths: AppPaths
    private let queue: SyncQueue
    private let inbox: SyncInbox
    private let materializer: SyncMaterializer
    private let preparer: SyncAttachmentPreparer
    private let transport: any SyncTransport
    private let blobs: any SyncBlobTransport
    private let vaultKey: SymmetricKey
    private let accountID: String
    private var vaultIntakeRunning = false
    private var running: Task<SyncRunSummary, any Error>?
    private var closed = false

    public init(database: AppDatabase, paths: AppPaths, accountID: String, vaultKey: SymmetricKey,
                transport: any SyncTransport, blobs: any SyncBlobTransport, coordinator: (any SyncCommitCoordinator)? = nil) {
        self.database = database; self.paths = paths; self.vaultKey = vaultKey; self.transport = transport; self.blobs = blobs; self.accountID = accountID
        queue = SyncQueue(database: database); inbox = SyncInbox(database: database)
        materializer = SyncMaterializer(database: database, paths: paths, accountID: accountID, vaultKey: vaultKey, blobs: blobs, coordinator: coordinator)
        preparer = SyncAttachmentPreparer(database: database, paths: paths, accountID: accountID, vaultKey: vaultKey)
    }

    public func synchronize(noteAccess: LockedNoteAccess? = nil, remoteNotePassword: String? = nil) async throws -> SyncRunSummary {
        guard !closed else { throw CancellationError() }
        guard !vaultIntakeRunning else { throw SyncQueueError.snapshotUnavailable }
        if let running { return try await running.value }
        let task = Task { try await self.cycle(noteAccess: noteAccess, remoteNotePassword: remoteNotePassword) }
        running = task
        do { let result = try await task.value; running = nil; return result }
        catch { running = nil; throw error }
    }

    /// An authenticated envelope found by `scanPendingNoteVault`, not yet installed.
    public struct PendingNoteVault: Sendable {
        fileprivate let entity: SyncEntity, bytes: Data, cursor: Int64, accountID: String, noteKey: SymmetricKey
    }

    /// Fetch only an authenticated note-vault envelope. The pull is read-only: no cursor,
    /// acknowledgement, inbox, note, attachment or journal is changed by this operation.
    public func recoverPendingNoteVault(password: String) async throws -> Bool {
        guard let found = try await scanPendingNoteVault(password: password) else { return false }
        return try await installPendingNoteVault(found)
    }

    public func unopenableLockedNoteCount(for found: PendingNoteVault) async throws -> Int {
        try await database.pool.read { try VaultIntakeKeyProof.unopenableCount(key: found.noteKey, in: $0).0 }
    }

    /// The read-only download (S7: hosts run it outside their library fence).
    public func scanPendingNoteVault(password: String) async throws -> PendingNoteVault? {
        guard let (entity, bytes, cursor) = try await scanPendingVaultEnvelope() else { return nil }
        let envelope = try JSONDecoder().decode(CryptoEnvelope.self, from: bytes)
        let noteKey = try envelope.unwrap(password: password)
        try Task.checkCancellation()
        return PendingNoteVault(entity: entity, bytes: bytes, cursor: cursor, accountID: accountID, noteKey: noteKey)
    }

    /// An empty successful pull is distinct from an offline or invalid response.
    public func pendingNoteVaultIsAbsent() async throws -> Bool {
        try await scanPendingVaultEnvelope() == nil
    }

    private func scanPendingVaultEnvelope() async throws -> (SyncEntity, Data, Int64)? {
        guard !closed, running == nil, !vaultIntakeRunning else { throw SyncQueueError.snapshotUnavailable }
        vaultIntakeRunning = true
        defer { vaultIntakeRunning = false }
        var cursor: Int64 = 0, candidate: SyncEntity?, keyID: String?, reachedEnd = false
        for _ in 0..<10_000 {
            try Task.checkCancellation()
            let page = try await transport.pull(after: cursor)
            guard page.cursor >= cursor, page.cursor <= SyncWire.maximumRevision, page.changes.count <= 500,
                  !page.hasMore || !page.changes.isEmpty else { throw SyncInboxError.invalidPage }
            var previous = cursor
            for entity in page.changes {
                _ = try JSONDecoder().decode(SyncEntity.self, from: JSONEncoder().encode(entity))
                guard entity.sequence > previous, entity.sequence <= page.cursor else { throw SyncInboxError.invalidPage }
                previous = entity.sequence
                if entity.mutation.entityType == .keyBundle {
                    if let keyID, keyID != entity.mutation.entityId { throw SyncProtocolError.invalidPayload }
                    if let candidate, entity.revision <= candidate.revision { throw SyncInboxError.sequenceCollision }
                    keyID = entity.mutation.entityId; candidate = entity
                }
            }
            guard previous == page.cursor else { throw SyncInboxError.invalidPage }
            cursor = page.cursor
            if !page.hasMore { reachedEnd = true; break }
        }
        // A bounded scan that has not reached the end must not install an older key.
        guard reachedEnd else { throw SyncInboxError.invalidPage }
        if candidate == nil || candidate?.mutation.tombstone == true {
            let localCursor = try await database.pool.read { try Int64.fetchOne($0, sql: "SELECT sequence FROM sync_cursor WHERE id=1") ?? 0 }
            guard localCursor <= cursor else { throw SyncInboxError.invalidPage }
            return nil
        }
        guard let entity = candidate else { return nil }
        guard entity.mutation.ciphertext != nil,
              entity.mutation.payloadRef == nil else { throw SyncProtocolError.invalidPayload }
        let reader = SyncPayloadReader(accountID: accountID, vaultKey: vaultKey, blobs: blobs)
        guard case .lockEnvelope(let bytes) = try await reader.read(entity) else { throw SyncProtocolError.invalidPayload }
        try Task.checkCancellation()
        return (entity, bytes, cursor)
    }

    /// Installs only the envelope, in one write that re-checks account, cursor watermark and the
    /// local key state; hosts fence just this step.
    public func installPendingNoteVault(_ found: PendingNoteVault) async throws -> Bool {
        guard !closed, running == nil, !vaultIntakeRunning else { throw SyncQueueError.snapshotUnavailable }
        vaultIntakeRunning = true
        defer { vaultIntakeRunning = false }
        let entity = found.entity, bytes = found.bytes, scannedCursor = found.cursor, activeAccountID = found.accountID
        return try await database.pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1") == activeAccountID,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM crypto_envelope) OR EXISTS(SELECT 1 FROM privacy_transition) OR EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='keyBundle') OR EXISTS(SELECT 1 FROM sync_outbox WHERE entityType='keyBundle')") == false else { throw SyncQueueError.snapshotUnavailable }
            try VaultIntakeKeyProof.requireMatch(key: found.noteKey, in: db)
            guard (try Int64.fetchOne(db, sql: "SELECT sequence FROM sync_cursor WHERE id=1") ?? 0) <= scannedCursor else { return false }
            let shadowKeys = try Data.fetchAll(db, sql: "SELECT wireEntity FROM sync_shadow WHERE entityType='keyBundle'")
            for raw in shadowKeys {
                let shadow = try JSONDecoder().decode(SyncEntity.self, from: raw)
                guard shadow.mutation.entityId == entity.mutation.entityId else { throw SyncInboxError.sequenceCollision }
                guard shadow.sequence <= entity.sequence, shadow.revision <= entity.revision else { return false }
                guard shadow.revision != entity.revision || shadow == entity else { throw SyncInboxError.sequenceCollision }
            }
            let states = try Row.fetchAll(db, sql: "SELECT entityId,serverRevision FROM sync_entity_state WHERE entityType='keyBundle'")
            for state in states {
                guard (state["entityId"] as String) == entity.mutation.entityId else { throw SyncInboxError.sequenceCollision }
                guard (state["serverRevision"] as Int64) <= entity.revision else { return false }
            }
            let inboxKeys = try Data.fetchAll(db, sql: "SELECT wireEntity FROM sync_inbox WHERE entityType='keyBundle'")
            for raw in inboxKeys {
                let existing = try JSONDecoder().decode(SyncEntity.self, from: raw)
                guard existing.mutation.entityId == entity.mutation.entityId else { throw SyncInboxError.sequenceCollision }
                guard existing.sequence <= entity.sequence, existing.revision <= entity.revision else { return false }
                guard existing.revision != entity.revision || existing == entity else { throw SyncInboxError.sequenceCollision }
            }
            try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
            try db.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [bytes])
            try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            return true
        }
    }

    public func cancelCurrentRun() async {
        let task = running; task?.cancel()
        _ = try? await task?.value
    }

    public func shutdown() async {
        closed = true
        let task = running; task?.cancel()
        _ = try? await task?.value
        running = nil
    }

    private func cycle(noteAccess: LockedNoteAccess?, remoteNotePassword: String?) async throws -> SyncRunSummary {
        var summary = SyncRunSummary()
        var deferredConflicts = Set<String>()
        _ = try AttachmentFiles(paths: paths, database: database).recover()
        try NotePrivacy(store: NoteStore(db: database, notifier: nil, paths: paths)).finishPendingCleanup()
        try materializer.recoverImportCleanup()
        let enabled = try await database.pool.read { try Bool.fetchOne($0, sql: "SELECT enabled FROM sync_control WHERE id=1") == true }
        // Pull before the upload backlog so short background runs durably receive changes.
        try await pull(into: &summary)
        // New notes cannot conflict with an immutable local upload; make them visible even
        // when the following upload backlog outlives a foreground/background run.
        // Pending key envelopes must apply first, including first-sync vault conversion.
        let newNotes = try await database.pool.read { db in
            try Data.fetchAll(db, sql: """
                SELECT wireEntity FROM sync_inbox i WHERE entityType='note'
                  AND NOT EXISTS(SELECT 1 FROM sync_inbox newer WHERE newer.entityType=i.entityType
                    AND newer.entityId=i.entityId AND newer.sequence>i.sequence)
                  AND NOT EXISTS(SELECT 1 FROM sync_inbox WHERE entityType='keyBundle')
                  AND NOT EXISTS(SELECT 1 FROM note n WHERE n.id=i.entityId)
                  AND NOT EXISTS(SELECT 1 FROM sync_entity_state s WHERE s.entityType='note' AND s.entityId=i.entityId)
                  AND NOT EXISTS(SELECT 1 FROM sync_dirty d WHERE d.entityType='note' AND d.localId=i.entityId)
                  AND NOT EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entityType='note' AND o.localId=i.entityId)
                ORDER BY sequence
                """).map { try JSONDecoder().decode(SyncEntity.self, from: $0) }
        }
        for entity in newNotes {
            try Task.checkCancellation()
            do {
                let result = try await materializer.apply(entity, noteAccess: noteAccess, remoteNotePassword: remoteNotePassword)
                if result == .applied || result == .unchanged { summary.applied += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Leave failed early imports queued for the final pass, after upload receipts.
                try Task.checkCancellation()
            }
        }
        // Recover upload receipts before reconciliation so privacy/attachment conflicts keep
        // their existing ordering, while received ciphertext and the cursor are already durable.
        if enabled { try await upload(into: &summary, deferredConflicts: &deferredConflicts, noteAccess: noteAccess, remoteNotePassword: remoteNotePassword) }
        try await pull(into: &summary)
        // Dependency order is not wire order: attachment descriptors may precede the parent
        // note, while lock envelopes must exist before protected note bodies are visible.
        var progressed = true
        while progressed {
            try Task.checkCancellation(); progressed = false
            summary.waitingForUploads = 0
            let pending = try await database.pool.read { db in
                try Data.fetchAll(db, sql: """
                    SELECT wireEntity FROM sync_inbox ORDER BY
                      CASE entityType WHEN 'keyBundle' THEN 0 WHEN 'note' THEN 1 ELSE 2 END,sequence
                    """).map { try JSONDecoder().decode(SyncEntity.self, from: $0) }
            }
            for entity in pending {
                try Task.checkCancellation()
                let result = try await materializer.apply(entity, noteAccess: noteAccess, remoteNotePassword: remoteNotePassword)
                if result == .passwordChanged {
                    summary.applied += 1; summary.passwordRefreshRequired = true
                    return try await finishSummary(summary, deferredConflicts: deferredConflicts)
                }
                if result == .waitingForUpload { summary.waitingForUploads += 1 }
                if result == .applied || result == .unchanged { summary.applied += 1; progressed = true }
            }
        }
        if enabled { try await upload(into: &summary, deferredConflicts: &deferredConflicts, noteAccess: noteAccess, remoteNotePassword: remoteNotePassword) }
        return try await finishSummary(summary, deferredConflicts: deferredConflicts)
    }

    private func pull(into summary: inout SyncRunSummary) async throws {
        var more = true
        while more {
            try Task.checkCancellation()
            let cursor = try inbox.cursor()
            let page = try await transport.pull(after: cursor)
            try inbox.persist(page, requestedAfter: cursor)
            summary.downloaded += page.changes.count
            try await transport.acknowledge(page.cursor)
            more = page.hasMore
        }
    }

    private func finishSummary(_ value: SyncRunSummary, deferredConflicts: Set<String>) async throws -> SyncRunSummary {
        var summary = value
        let uploads = try queue.pendingUploadCounts(paths: paths)
        summary.pendingUploads = uploads.pendingUploads
        summary.unavailableAttachments = uploads.unavailableAttachments
        summary.pendingDownloads = try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_inbox") ?? 0 }
        summary.waitingForUnlock = try inbox.waitingForUnlockCount()
        summary.deferredConflicts = try await database.pool.read { db in
            let queued = Set(try String.fetchAll(db, sql: "SELECT mutationId FROM sync_outbox"))
            return deferredConflicts.intersection(queued).count
        }
        return summary
    }

    private func upload(into summary: inout SyncRunSummary, deferredConflicts: inout Set<String>, noteAccess: LockedNoteAccess?, remoteNotePassword: String?) async throws {
        var deferred = Set<String>()
        for _ in 0..<20 {
            try Task.checkCancellation()
            // Reconciliation can create conflict-copy files during the preceding batch.
            // Prepare those before their note snapshot is queued in this same cycle.
            try await preparer.preparePending(limit: 1000)
            // Each preparation commits independently; batches below enforce the transport size limit.
            for _ in 0..<100 { if try queue.prepareNext(vaultKey: vaultKey) == nil { break } }
            let excluded = deferred
            let batch = try await database.pool.read { db -> [SyncMutation] in
                let cursor = try Data.fetchCursor(db, sql: "SELECT wireMutation FROM sync_outbox ORDER BY ordinal")
                var selected: [SyncMutation] = [], bytes = 32
                while let data = try cursor.next() {
                    let mutation = try JSONDecoder().decode(SyncMutation.self, from: data)
                    if excluded.contains(mutation.mutationId) { continue }
                    let size = try JSONEncoder().encode(mutation).count + 1
                    if selected.count == 100 || bytes + size > 900_000 { break }
                    selected.append(mutation); bytes += size
                }
                return selected
            }
            guard !batch.isEmpty else { break }
            try await blobs.ensureUploaded(batch.flatMap(\.blobRefs))
            let response = try await transport.push(batch)
            guard response.results.count == batch.count else { throw SyncHTTPError.invalidResponse }
            for (next, result) in zip(batch, response.results) {
                guard result.mutationId == next.mutationId else { throw SyncHTTPError.invalidResponse }
                if result.status == .accepted {
                    guard let receipt = result.entity else { throw SyncHTTPError.invalidResponse }
                    try queue.accept(receipt); summary.uploaded += 1
                }
            }
            for (next, result) in zip(batch, response.results) {
                switch result.status {
            case .accepted:
                break
            case .conflict:
                guard let current = result.current, current.mutation.entityType == next.entityType,
                      current.mutation.entityId == next.entityId, current.revision > next.parentRevision else { throw SyncHTTPError.invalidResponse }
                try inbox.retainConflict(current)
                let applied = try await materializer.apply(current, rejectedMutationID: next.mutationId, noteAccess: noteAccess, remoteNotePassword: remoteNotePassword)
                if applied == .applied || applied == .unchanged { summary.applied += 1 }
                else { deferred.insert(next.mutationId); deferredConflicts.insert(next.mutationId) }
            case .missingBlob:
                // A previously acknowledged blob can have expired remotely. Retry from
                // durable local ciphertext instead of trusting the stale uploaded flag.
                try await database.pool.write { db in
                    for hash in next.blobRefs { try db.execute(sql: "UPDATE sync_blob_state SET uploaded=0 WHERE hash=?", arguments: [hash]) }
                }
                throw SyncProtocolError.invalidPayload
            case .mutationReused: throw SyncQueueError.invalidReceipt
                }
            }
        }
    }
}
