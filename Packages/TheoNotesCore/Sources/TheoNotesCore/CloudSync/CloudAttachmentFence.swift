// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// `SyncAttachmentPreparer.preparePending` skips attachments that have a row in `sync_outbox` (an upload in flight), so that a
/// file is not prepared again while its snapshot travels. A CloudKit library never has outbox rows, so that exclusion is
/// vacuous there and an attachment with a snapshot in flight would be prepared again (a new cache generation, possibly a new
/// blob) underneath it. This type replaces the exclusion by an explicit fence against the CloudKit state (E0 record, section 3):
/// an attachment is not prepared while it has a `ck_inflight` snapshot, a quarantine row, a pause, or a fetched version waiting
/// for its merge. Everything else is the reused preparer (`prepare(id:)`), unchanged. Dirty generations keep rising meanwhile
/// and the attachment is prepared on a later cycle.
actor CloudAttachmentPreparer {
    private let database: AppDatabase
    private let preparer: SyncAttachmentPreparer
    private var scanAfter: String?

    init(database: AppDatabase, preparer: SyncAttachmentPreparer) {
        self.database = database; self.preparer = preparer
    }

    @discardableResult
    func preparePending(limit: Int = 100) async throws -> Int {
        func candidates(after: String?) throws -> [String] {
            try database.pool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT d.localId FROM sync_dirty d WHERE d.entityType='attachment' AND d.tombstone=0
                      AND NOT EXISTS(SELECT 1 FROM ck_inflight f WHERE f.entityType='attachment' AND f.entityId=d.localId)
                      AND NOT EXISTS(SELECT 1 FROM ck_quarantine q WHERE q.entityType='attachment' AND q.entityId=d.localId AND q.ignoredByUser=0)
                      AND NOT EXISTS(SELECT 1 FROM ck_missing m WHERE m.entityType='attachment' AND m.entityId=d.localId)
                      AND NOT EXISTS(SELECT 1 FROM ck_remote r WHERE r.entityType='attachment' AND r.entityId=d.localId)
                      AND (? IS NULL OR d.localId>?)
                    ORDER BY d.localId LIMIT ?
                    """, arguments: [after, after, max(1, min(limit, 1000))])
            }
        }
        var ids = try candidates(after: scanAfter)
        if ids.isEmpty, scanAfter != nil { scanAfter = nil; ids = try candidates(after: nil) }
        var ready = 0
        for id in ids {
            try Task.checkCancellation()
            scanAfter = id
            do {
                // The fence is checked again right before the work: a snapshot may have appeared since the list was read.
                guard try await database.pool.read({ try Self.isFree(id, in: $0) }) else { continue }
                if try await preparer.prepare(id: id) { ready += 1 }
            } catch SyncQueueError.snapshotUnavailable { continue }
        }
        return ready
    }

    static func isFree(_ id: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM ck_inflight WHERE entityType='attachment' AND entityId=?)
               AND NOT EXISTS(SELECT 1 FROM ck_remote WHERE entityType='attachment' AND entityId=?)
            """, arguments: [id, id]) ?? false
    }
}
